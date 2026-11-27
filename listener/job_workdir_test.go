package listener

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/actions/scaleset"
	"github.com/hashicorp/go-retryablehttp"
)

type jitTransport func(*http.Request) (*http.Response, error)

func (transport jitTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	return transport(req)
}

// Capture the real minter's JSON request without opening a network connection.
func captureJITMinter(t *testing.T) (*ClientJITMinter, *[]scaleset.RunnerScaleSetJitRunnerSetting) {
	t.Helper()
	var settings []scaleset.RunnerScaleSetJitRunnerSetting
	payload := fmt.Sprintf(`{"exp":%d}`, time.Now().Add(time.Hour).Unix())
	token := "eyJhbGciOiJIUzI1NiJ9." + base64.RawURLEncoding.EncodeToString([]byte(payload)) + ".stub"
	httpClient := retryablehttp.NewClient()
	httpClient.RetryMax = 0
	// The SDK requires a concrete *http.Transport. Register a handler for
	// HTTPS so every fixture request is handled in memory.
	transport := &http.Transport{}
	transport.RegisterProtocol("https", jitTransport(func(req *http.Request) (*http.Response, error) {
		if req.Method != http.MethodPost {
			return nil, fmt.Errorf("unexpected method %s for %s", req.Method, req.URL.Path)
		}
		status, body := http.StatusOK, ""
		switch {
		case strings.HasSuffix(req.URL.Path, "/registration-token"):
			status, body = http.StatusCreated, `{"token":"registration-token"}`
		case strings.HasSuffix(req.URL.Path, "/actions/runner-registration"):
			body = fmt.Sprintf(`{"url":"https://actions.example.invalid","token":%q}`, token)
		case strings.HasSuffix(req.URL.Path, "/42/generatejitconfig"):
			var setting scaleset.RunnerScaleSetJitRunnerSetting
			if err := json.NewDecoder(req.Body).Decode(&setting); err != nil {
				return nil, err
			}
			settings = append(settings, setting)
			body = `{"encodedJITConfig":"jit"}`
		default:
			return nil, fmt.Errorf("unexpected path %s", req.URL.Path)
		}
		return &http.Response{
			StatusCode: status,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(body)),
		}, nil
	}))
	httpClient.HTTPClient.Transport = transport
	client, err := scaleset.NewClientWithPersonalAccessToken(scaleset.NewClientWithPersonalAccessTokenConfig{
		GitHubConfigURL:     "https://github.com/acme",
		PersonalAccessToken: "stub",
	}, scaleset.WithRetryableHTTPClint(httpClient))
	if err != nil {
		t.Fatal(err)
	}
	return &ClientJITMinter{Client: client, ScaleSetID: 42}, &settings
}

func TestMinterWorkFolder(t *testing.T) {
	// HostContext.GetDirectory combines the runner root with settings.WorkFolder.
	// An absolute second argument supplies the work directory directly.
	// https://github.com/actions/runner/blob/main/src/Runner.Common/HostContext.cs#L386-L393
	workdir := filepath.Join(t.TempDir(), "jit-job.0123abcd")
	for _, tc := range []struct{ name, input, want string }{
		{"default", "", "_work"},
		{"absolute", workdir, workdir},
	} {
		t.Run(tc.name, func(t *testing.T) {
			minter, captured := captureJITMinter(t)
			ctx := context.Background()
			var err error
			// Match both signatures so the red step compiles against the current minter.
			switch m := any(minter).(type) {
			case interface {
				Mint(context.Context, string, []string, string) (string, error)
			}:
				_, err = m.Mint(ctx, "job", nil, tc.input)
			case interface {
				Mint(context.Context, string, []string) (string, error)
			}:
				_, err = m.Mint(ctx, "job", nil)
			default:
				t.Fatal("unrecognized Mint signature")
			}
			if err != nil {
				t.Fatal(err)
			}
			if len(*captured) != 1 || (*captured)[0].WorkFolder != tc.want {
				t.Errorf("mint requests = %+v, want one with WorkFolder %q", *captured, tc.want)
			}
		})
	}
}

type observedWorkdirProvisioner struct {
	*ContainerProvisioner
	done chan error
}

func (p observedWorkdirProvisioner) Provision(ctx context.Context, req ProvisionRequest) error {
	err := p.ContainerProvisioner.Provision(ctx, req)
	p.done <- err
	return err
}

func TestListenerJobWorkdir(t *testing.T) {
	for _, tc := range []struct {
		name         string
		socket       string
		overrideRoot bool
	}{
		{name: "explicit root", socket: "/var/run/docker.sock", overrideRoot: true},
		{name: "default root", socket: "/var/run/docker.sock"},
		{name: "socket off"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			root := filepath.Join(home, "work")
			t.Setenv("RUNNER_HOME", home)
			t.Setenv("RUNNER_WORK_ROOT", "")
			if tc.overrideRoot {
				root = t.TempDir()
				t.Setenv("RUNNER_WORK_ROOT", root)
			}
			t.Setenv("RUNNER_JOB_WORKDIR", filepath.Join(home, "inherited"))
			capture := filepath.Join(t.TempDir(), "provision")
			t.Setenv("WORKDIR_TEST_CAPTURE", capture)
			script := writeScript(t, `#!/usr/bin/env bash
printf '%s\n' "$1" "${RUNNER_JOB_WORKDIR-unset}" > "${WORKDIR_TEST_CAPTURE}"
`)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			prov := observedWorkdirProvisioner{
				ContainerProvisioner: &ContainerProvisioner{Script: script},
				done:                 make(chan error, 1),
			}
			sess := &fakeSession{
				messages: []*scaleset.RunnerScaleSetMessage{
					msgWithAssigned(1, 1, assigned(1, "job\t-A.b_1", "linux")),
				},
				cancel: cancel,
				beforePoll: func(lastMessageID int) {
					if lastMessageID != 1 {
						return
					}
					select {
					case err := <-prov.done:
						if err != nil {
							t.Errorf("provisioner script: %v", err)
						}
					case <-ctx.Done():
						t.Error("provisioner did not complete before shutdown")
					}
				},
			}
			minter, minted := captureJITMinter(t)
			l := New(sess, minter, prov, Config{
				Image: "runner-image", DockerSocket: tc.socket, MaxRunners: 1,
			})
			if err := l.Listen(ctx); err != nil {
				t.Fatal(err)
			}

			const jobID = "job-A.b_1"
			if len(*minted) != 1 {
				t.Fatalf("minted %d runner configurations, want 1", len(*minted))
			}
			folder := (*minted)[0].WorkFolder
			workdir := ""
			if tc.socket == "" {
				if folder != "_work" {
					t.Errorf("WorkFolder = %q, want _work", folder)
				}
			} else {
				workdir = folder
				namePattern := regexp.MustCompile(`^jit-` + regexp.QuoteMeta(jobID) + `\.[0-9a-fA-F]{8,}$`)
				if !filepath.IsAbs(folder) || filepath.Dir(folder) != root ||
					!namePattern.MatchString(filepath.Base(folder)) {
					t.Errorf("WorkFolder = %q, want %s/jit-%s.<8+ hex digits>", folder, root, jobID)
				}
			}
			got, err := os.ReadFile(capture)
			if err != nil {
				t.Fatal(err)
			}
			if want := jobID + "\n" + workdir + "\n"; string(got) != want {
				t.Errorf("provisioner job ID and RUNNER_JOB_WORKDIR = %q, want %q", got, want)
			}
		})
	}
}

func TestListenerRefusesUnsafeSocketJobIDs(t *testing.T) {
	for _, id := range []string{"", ".", "..", "a/b", "a b", "a:b", "aé", "\t"} {
		t.Run(fmt.Sprintf("%q", id), func(t *testing.T) {
			t.Setenv("RUNNER_HOME", t.TempDir())
			t.Setenv("RUNNER_WORK_ROOT", t.TempDir())
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			sess := &fakeSession{
				messages: []*scaleset.RunnerScaleSetMessage{
					msgWithAssigned(1, 1, assigned(1, id, "linux")),
					msgWithAssigned(2, 2, assigned(2, "safe-next", "linux")),
				},
				cancel: cancel,
			}
			minter, minted := captureJITMinter(t)
			prov := &recordingProvisioner{}
			l := New(sess, minter, prov, Config{
				Image: "runner-image", DockerSocket: "/var/run/docker.sock", MaxRunners: 2,
			})
			if err := l.Listen(ctx); err != nil {
				t.Fatalf("listener stopped after unsafe assignment: %v", err)
			}
			var mintedSafe, provisionedSafe bool
			for _, setting := range *minted {
				if setting.Name == id || setting.Name == canonicalJobID(id) {
					t.Errorf("minted unsafe job %q", id)
				}
				mintedSafe = mintedSafe || setting.Name == "safe-next"
			}
			for _, job := range prov.jobs {
				if job.RequestID == 1 {
					t.Errorf("provisioned unsafe job %q", id)
				}
				provisionedSafe = provisionedSafe || job.JobID == "safe-next"
			}
			if !mintedSafe || !provisionedSafe {
				t.Error("listener did not mint and provision the following safe assignment")
			}
		})
	}
}

func TestScriptReaperPassesPurgeImage(t *testing.T) {
	const image = "ghcr.io/acme/socket-runner:1"
	capture := filepath.Join(t.TempDir(), "reap")
	t.Setenv("WORKDIR_TEST_CAPTURE", capture)
	t.Setenv("RUNNER_PURGE_IMAGE", "inherited-image")
	reaper := &ScriptReaper{Script: writeScript(t, `#!/usr/bin/env bash
printf '%s\n' "${RUNNER_PURGE_IMAGE-unset}" "$@" > "${WORKDIR_TEST_CAPTURE}"
`)}
	reaper.Image = image
	if err := reaper.Reap(context.Background(), []string{"job-A.b_1"}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(capture)
	if err != nil {
		t.Fatal(err)
	}
	if want := image + "\njob-A.b_1\n"; string(got) != want {
		t.Errorf("reaper image and tracked ids = %q, want %q", got, want)
	}
}

package overalls

import (
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/quick"
)

func TestNativeReviewedTrust(t *testing.T) {
	for goos, expected := range map[string]string{"freebsd": "/etc/ssl/cert.pem", "illumos": "/etc/ssl/cacert.pem", "solaris": "/etc/ssl/cacert.pem", "linux": "", "windows": ""} {
		if got := nativeTrustPath(goos); got != expected {
			t.Fatalf("wrong trust path for %s", goos)
		}
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer server.Close()
	path := filepath.Join(t.TempDir(), "roots.pem")
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if err := os.WriteFile(path, certificate, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SSL_CERT_FILE", filepath.Join(t.TempDir(), "foreign-roots"))
	roots, err := nativeRoots(path)
	if err != nil {
		t.Fatal(err)
	}
	transport := Direct().(*http.Transport)
	transport.TLSClientConfig.RootCAs = roots
	defer transport.CloseIdleConnections()
	response, err := (&http.Client{Transport: transport}).Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatal("reviewed trust failed actual TLS request")
	}
	for _, contents := range [][]byte{nil, []byte("malformed"), []byte(strings.Repeat("x", 2*1024*1024+1))} {
		if err := os.WriteFile(path, contents, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := nativeRoots(path); !errors.Is(err, errTrust) {
			t.Fatal("accepted invalid native roots")
		}
	}
	if _, err := nativeRoots(path + ".absent"); !errors.Is(err, errTrust) {
		t.Fatal("accepted missing native roots")
	}
	if response, err := (refusedTrust{}).RoundTrip(nil); response != nil || !errors.Is(err, errTrust) {
		t.Fatal("invalid native trust did not refuse dispatch")
	}
}

type roundTripper func(*http.Request) (*http.Response, error)

func (f roundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestRoutes(t *testing.T) {
	for origin, prefix := range prefixes {
		u, _ := url.Parse("https://" + origin + "/a%2Fb?ref=branch%2Fname")
		got, err := Route(u)
		if err != nil || got.String() != "https://"+Host+prefix+"/a%2Fb?ref=branch%2Fname" {
			t.Fatalf("%s: %v %v", origin, got, err)
		}
	}
	for _, raw := range []string{"http://api.github.com/x", "https://user:pass@github.com/x", "https://github.com:444/x", "https://github.com.evil/x", "https://github.com/x#token", "https://github.com/a/../b", "https://github.com/a/%2e%2e/b", "https://github.com/a%5cb", "https://github.com/x?%74oken=secret", "https://" + Host + "/arbitrary", "https://" + Host + "/capabilities/short"} {
		u, _ := url.Parse(raw)
		if _, err := Route(u); !errors.Is(err, ErrOrigin) {
			t.Fatalf("accepted %s", raw)
		}
	}
}

func TestRoundTripStripsAuthorityAndStreams(t *testing.T) {
	body := strings.NewReader("streaming request")
	req, _ := http.NewRequest(http.MethodPost, "https://api.github.com/repos/a/b/issues", body)
	req.Header = http.Header{"authorization": {"secret"}, "Cookie": {"secret"}, "Proxy-Authorization": {"secret"}, "X-Idempotency-Key": {"repeat"}, "Accept": {"application/json"}}
	called := 0
	rt := Wrap(roundTripper(func(out *http.Request) (*http.Response, error) {
		called++
		if out.Host != Host || out.URL.Path != "/api/repos/a/b/issues" || out.Body != req.Body {
			t.Fatal("request changed outside routing")
		}
		for key := range out.Header {
			if strings.Contains(strings.ToLower(key), "authorization") || strings.Contains(strings.ToLower(key), "cookie") || strings.Contains(strings.ToLower(key), "idempotency") {
				t.Fatal("guest authority escaped")
			}
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Set-Cookie": {"secret"}}, Body: io.NopCloser(strings.NewReader("streaming response"))}, nil
	}))
	response, err := rt.RoundTrip(req)
	if err != nil || response.Request != req || called != 1 || response.Header.Get("Set-Cookie") != "" {
		t.Fatal("incorrect dispatch")
	}
	if req.Header.Get("Cookie") != "secret" {
		t.Fatal("mutated caller")
	}
}

func TestEveryMutationRedirectRefused(t *testing.T) {
	for _, method := range []string{"POST", "PUT", "PATCH", "DELETE"} {
		for _, status := range []int{301, 302, 303, 307, 308} {
			attempts := 0
			client := &http.Client{Transport: Wrap(roundTripper(func(req *http.Request) (*http.Response, error) {
				attempts++
				return &http.Response{StatusCode: status, Header: http.Header{"Location": {"https://api.github.com/redirect"}}, Body: io.NopCloser(strings.NewReader(""))}, nil
			}))}
			req, _ := http.NewRequest(method, "https://api.github.com/start", strings.NewReader("body"))
			_, err := client.Do(req)
			if !errors.Is(err, ErrRedirect) || attempts != 1 {
				t.Fatalf("%s %d: %d %v", method, status, attempts, err)
			}
		}
	}
}

func TestRouteProperty(t *testing.T) {
	property := func(segment string) bool {
		u := &url.URL{Scheme: "https", Host: "api.github.com", Path: "/" + segment}
		route, err := Route(u)
		if err != nil {
			return true
		}
		return route.Scheme == "https" && route.Host == Host && route.User == nil && strings.HasPrefix(route.Path, "/api/") && route.RawQuery == u.RawQuery
	}
	if err := quick.Check(property, &quick.Config{MaxCount: 1000}); err != nil {
		t.Fatal(err)
	}
}

func TestDirectPolicy(t *testing.T) {
	tr := Direct().(*http.Transport)
	if tr.Proxy != nil || tr.TLSClientConfig.InsecureSkipVerify || !tr.DisableKeepAlives || tr.ForceAttemptHTTP2 || len(tr.TLSNextProto) != 0 {
		t.Fatal("direct transport policy changed")
	}
}

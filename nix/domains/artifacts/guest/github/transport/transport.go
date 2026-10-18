// Package overalls supplies the credential-free transport shared by managed
// GitHub CLI and Git LFS. Authentication and refresh are owned by Marshall.
package overalls

import (
	"crypto/tls"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const Host = "com-github.integration.internal"
const Marker = "overalls-managed-github"
const Source = "Marshall"
const Managed = true

var ErrManaged = errors.New("GitHub authentication is managed in Marshall")
var ErrOrigin = errors.New("unsupported managed GitHub destination")
var ErrRedirect = errors.New("managed GitHub mutations cannot follow redirects")

var prefixes = map[string]string{
	"api.github.com":             "/api",
	"uploads.github.com":         "/uploads",
	"github.com":                 "/git",
	"gist.github.com":            "/gist",
	"raw.githubusercontent.com":  "/raw",
	"gist.githubusercontent.com": "/gist-raw",
}

// Direct uses verified system roots and one HTTP/1 connection per request.
// In particular, environment proxies, TLS bypass settings and a reused
// connection's transparent transport retry cannot change this policy.
func Direct() http.RoundTripper {
	return &http.Transport{
		Proxy:                 nil,
		TLSClientConfig:       &tls.Config{MinVersion: tls.VersionTLS12},
		TLSNextProto:          map[string]func(string, *tls.Conn) http.RoundTripper{},
		DisableKeepAlives:     true,
		ForceAttemptHTTP2:     false,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
}

// Wrap translates the logical GitHub origin immediately before dispatch.
// The caller supplies Direct in production; injection is for transport tests.
func Wrap(next http.RoundTripper) http.RoundTripper {
	return &transport{next: next}
}

type transport struct{ next http.RoundTripper }

func Read(method string) bool { return method == http.MethodGet || method == http.MethodHead }

// @cc [owner:ghuntley,label:security] managed-roundtrip-closed-authority
// RoundTrip MUST reject non-HTTPS/foreign origins and redirects from a mutation,
// preserve the streaming body, and remove all guest authentication and cookies.
func (t *transport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Response != nil && req.Response.Request != nil && !Read(req.Response.Request.Method) {
		return nil, ErrRedirect
	}
	u, err := Route(req.URL)
	if err != nil {
		return nil, err
	}
	out := req.Clone(req.Context())
	out.URL = u
	out.Host = Host
	out.Header = req.Header.Clone()
	for key := range out.Header {
		switch strings.ToLower(key) {
		case "authorization", "proxy-authorization", "cookie", "cookie2", "idempotency-key", "x-idempotency-key":
			delete(out.Header, key)
		}
	}
	response, err := t.next.RoundTrip(out)
	if response != nil {
		response.Request = req
		response.Header.Del("Set-Cookie")
		response.Header.Del("Set-Cookie2")
	}
	return response, err
}

// Route preserves escaped paths and non-secret query parameters; it never
// interprets a caller-provided hostname as a broker target.
func Route(input *url.URL) (*url.URL, error) {
	if input == nil || input.Scheme != "https" || input.User != nil || input.Fragment != "" || input.Opaque != "" || (input.Port() != "" && input.Port() != "443") {
		return nil, ErrOrigin
	}
	host := strings.ToLower(input.Hostname())
	path := input.EscapedPath()
	if path == "" {
		path = "/"
	}
	if len(path) > 8192 || len(input.RawQuery) > 8192 || strings.HasPrefix(path, "//") || strings.ContainsAny(path, "\\\r\n\x00") {
		return nil, ErrOrigin
	}
	decoded, err := url.PathUnescape(path)
	if err != nil {
		return nil, ErrOrigin
	}
	for _, part := range strings.Split(decoded, "/") {
		if part == "." || part == ".." || strings.ContainsAny(part, "\\\r\n\x00") {
			return nil, ErrOrigin
		}
	}
	query, err := url.ParseQuery(input.RawQuery)
	if err != nil {
		return nil, ErrOrigin
	}
	for key := range query {
		switch strings.ToLower(key) {
		case "access_token", "refresh_token", "client_secret", "authorization", "token", "sig", "signature":
			return nil, ErrOrigin
		}
	}
	if host == Host {
		if !internalPath(path) {
			return nil, ErrOrigin
		}
	} else {
		prefix, exists := prefixes[host]
		if !exists {
			return nil, ErrOrigin
		}
		path = prefix + path
	}
	output := *input
	output.Host = Host
	output.Path, err = url.PathUnescape(path)
	if err != nil {
		return nil, ErrOrigin
	}
	output.RawPath = path
	return &output, nil
}

func internalPath(path string) bool {
	for _, prefix := range prefixes {
		if path == prefix || strings.HasPrefix(path, prefix+"/") {
			return true
		}
	}
	if selector, ok := strings.CutPrefix(path, "/capabilities/"); ok && len(selector) == 43 {
		for _, c := range selector {
			if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
				return false
			}
		}
		return true
	}
	return false
}

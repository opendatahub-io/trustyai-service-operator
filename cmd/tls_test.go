/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"crypto/tls"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func makeAPIServer(profileType string, custom map[string]interface{}) *unstructured.Unstructured {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{}}
	spec := map[string]interface{}{}
	if profileType != "" {
		profile := map[string]interface{}{"type": profileType}
		if custom != nil {
			profile["custom"] = custom
		}
		spec["tlsSecurityProfile"] = profile
	}
	obj.Object["spec"] = spec
	return obj
}

func TestParseTLSProfile(t *testing.T) {
	t.Run("nil profile returns Intermediate defaults", func(t *testing.T) {
		obj := &unstructured.Unstructured{Object: map[string]interface{}{
			"spec": map[string]interface{}{},
		}}
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2, got %d", minVer)
		}
		if len(ciphers) != len(intermediateCiphers) {
			t.Errorf("expected %d Intermediate ciphers, got %d", len(intermediateCiphers), len(ciphers))
		}
	})

	t.Run("Intermediate returns Intermediate defaults", func(t *testing.T) {
		obj := makeAPIServer("Intermediate", nil)
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2, got %d", minVer)
		}
		if len(ciphers) != len(intermediateCiphers) {
			t.Errorf("expected %d ciphers, got %d", len(intermediateCiphers), len(ciphers))
		}
	})

	t.Run("Modern returns TLS 1.3 with nil ciphers", func(t *testing.T) {
		obj := makeAPIServer("Modern", nil)
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS13 {
			t.Errorf("expected TLS 1.3, got %d", minVer)
		}
		if ciphers != nil {
			t.Errorf("expected nil ciphers for Modern, got %v", ciphers)
		}
	})

	t.Run("Old returns TLS 1.2 with nil ciphers", func(t *testing.T) {
		obj := makeAPIServer("Old", nil)
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2, got %d", minVer)
		}
		if ciphers != nil {
			t.Errorf("expected nil ciphers for Old, got %v", ciphers)
		}
	})

	t.Run("Custom with valid ciphers", func(t *testing.T) {
		obj := makeAPIServer("Custom", map[string]interface{}{
			"minTLSVersion": "VersionTLS12",
			"ciphers":       []interface{}{"ECDHE-RSA-AES128-GCM-SHA256"},
		})
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2, got %d", minVer)
		}
		if len(ciphers) != 1 || ciphers[0] != tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 {
			t.Errorf("expected 1 cipher TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, got %v", ciphers)
		}
	})

	t.Run("Custom with unsupported cipher logs and skips", func(t *testing.T) {
		obj := makeAPIServer("Custom", map[string]interface{}{
			"minTLSVersion": "VersionTLS12",
			"ciphers":       []interface{}{"DHE-RSA-AES128-GCM-SHA256", "ECDHE-RSA-AES128-GCM-SHA256"},
		})
		_, ciphers := parseTLSProfile(obj)
		if len(ciphers) != 1 {
			t.Errorf("expected 1 cipher (DHE dropped), got %d", len(ciphers))
		}
		if len(ciphers) == 1 && ciphers[0] != tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 {
			t.Errorf("expected TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, got %d", ciphers[0])
		}
	})

	t.Run("Custom with nil custom block returns Intermediate", func(t *testing.T) {
		obj := makeAPIServer("Custom", nil)
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2, got %d", minVer)
		}
		if len(ciphers) != len(intermediateCiphers) {
			t.Errorf("expected Intermediate ciphers, got %d", len(ciphers))
		}
	})

	t.Run("Unknown profile type returns Intermediate", func(t *testing.T) {
		obj := makeAPIServer("SomeFutureType", nil)
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2, got %d", minVer)
		}
		if len(ciphers) != len(intermediateCiphers) {
			t.Errorf("expected Intermediate ciphers, got %d", len(ciphers))
		}
	})

	t.Run("Custom with TLS 1.3 minVersion", func(t *testing.T) {
		obj := makeAPIServer("Custom", map[string]interface{}{
			"minTLSVersion": "VersionTLS13",
			"ciphers":       []interface{}{},
		})
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS13 {
			t.Errorf("expected TLS 1.3, got %d", minVer)
		}
		if len(ciphers) != 0 {
			t.Errorf("expected 0 ciphers, got %d", len(ciphers))
		}
	})

	t.Run("Custom with unknown minTLSVersion falls back to TLS 1.2", func(t *testing.T) {
		obj := makeAPIServer("Custom", map[string]interface{}{
			"minTLSVersion": "VersionTLS10",
			"ciphers":       []interface{}{"ECDHE-RSA-AES128-GCM-SHA256"},
		})
		minVer, _ := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2 fallback, got %d", minVer)
		}
	})

	t.Run("Custom with all unsupported ciphers returns empty slice", func(t *testing.T) {
		obj := makeAPIServer("Custom", map[string]interface{}{
			"minTLSVersion": "VersionTLS12",
			"ciphers":       []interface{}{"DHE-RSA-AES128-GCM-SHA256", "DHE-RSA-AES256-GCM-SHA384"},
		})
		minVer, ciphers := parseTLSProfile(obj)
		if minVer != tls.VersionTLS12 {
			t.Errorf("expected TLS 1.2, got %d", minVer)
		}
		if ciphers == nil {
			t.Fatal("expected non-nil empty slice, got nil (fail-closed guard needs non-nil)")
		}
		if len(ciphers) != 0 {
			t.Errorf("expected 0 ciphers (all unsupported dropped), got %d", len(ciphers))
		}
	})
}

func TestTLSVersionMap(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected uint16
		found    bool
	}{
		{"TLS 1.2", "VersionTLS12", tls.VersionTLS12, true},
		{"TLS 1.3", "VersionTLS13", tls.VersionTLS13, true},
		{"unknown", "VersionTLS10", 0, false},
		{"empty", "", 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := tlsVersionMap[tt.input]
			if ok != tt.found {
				t.Errorf("tlsVersionMap[%q] found=%v, want %v", tt.input, ok, tt.found)
			}
			if got != tt.expected {
				t.Errorf("tlsVersionMap[%q] = %d, want %d", tt.input, got, tt.expected)
			}
		})
	}
}

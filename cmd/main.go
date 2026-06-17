/*
Copyright 2023.

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
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"os"
	"time"

	kservev1alpha1 "github.com/kserve/kserve/pkg/apis/serving/v1alpha1"
	kservev1beta1 "github.com/kserve/kserve/pkg/apis/serving/v1beta1"
	routev1 "github.com/openshift/api/route/v1"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	nemoguardrailsv1alpha1 "github.com/trustyai-explainability/trustyai-service-operator/api/nemo_guardrails/v1alpha1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"slices"

	// Import all Kubernetes client auth plugins (e.g. Azure, GCP, OIDC, etc.)
	// to ensure that exec-entrypoint and run can make use of them.
	_ "k8s.io/client-go/plugin/pkg/client/auth"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	restclient "k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/metrics/server"
	ctrlwebhook "sigs.k8s.io/controller-runtime/pkg/webhook"

	evalhubv1 "github.com/trustyai-explainability/trustyai-service-operator/api/evalhub/v1"
	evalhubv1alpha1 "github.com/trustyai-explainability/trustyai-service-operator/api/evalhub/v1alpha1"
	gorchv1alpha1 "github.com/trustyai-explainability/trustyai-service-operator/api/gorch/v1alpha1"
	lmesv1alpha1 "github.com/trustyai-explainability/trustyai-service-operator/api/lmes/v1alpha1"
	tasv1 "github.com/trustyai-explainability/trustyai-service-operator/api/tas/v1"
	tasv1alpha1 "github.com/trustyai-explainability/trustyai-service-operator/api/tas/v1alpha1"
	"github.com/trustyai-explainability/trustyai-service-operator/controllers"
	"github.com/trustyai-explainability/trustyai-service-operator/controllers/constants"
	"github.com/trustyai-explainability/trustyai-service-operator/controllers/utils"
	kueuev1beta1 "sigs.k8s.io/kueue/apis/kueue/v1beta1"
	//+kubebuilder:scaffold:imports
)

const serviceEvalHub = "EVALHUB"

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(tasv1alpha1.AddToScheme(scheme))
	utilruntime.Must(tasv1.AddToScheme(scheme))
	utilruntime.Must(lmesv1alpha1.AddToScheme(scheme))
	utilruntime.Must(evalhubv1alpha1.AddToScheme(scheme))
	utilruntime.Must(evalhubv1.AddToScheme(scheme))
	utilruntime.Must(monitoringv1.AddToScheme(scheme))
	utilruntime.Must(kservev1alpha1.AddToScheme(scheme))
	utilruntime.Must(kservev1beta1.AddToScheme(scheme))
	utilruntime.Must(routev1.AddToScheme(scheme))
	utilruntime.Must(apiextensionsv1.AddToScheme(scheme))
	utilruntime.Must(kueuev1beta1.AddToScheme(scheme))
	utilruntime.Must(gorchv1alpha1.AddToScheme(scheme))
	utilruntime.Must(nemoguardrailsv1alpha1.AddToScheme(scheme))
	//+kubebuilder:scaffold:scheme
}

// +kubebuilder:rbac:groups=config.openshift.io,resources=apiservers,resourceNames=cluster,verbs=get;list;watch

func fetchTLSOpts(cfg *restclient.Config) []func(*tls.Config) {
	var tlsOpts []func(*tls.Config)
	bootstrapClient, err := client.New(cfg, client.Options{Scheme: scheme})
	if err != nil {
		setupLog.Info("Failed to create bootstrap client for TLS profile, using hardened defaults")
		tlsOpts = append(tlsOpts, func(c *tls.Config) {
			c.MinVersion = tls.VersionTLS12
			c.NextProtos = []string{"h2", "http/1.1"}
		})
		return tlsOpts
	}

	apiServer := &unstructured.Unstructured{}
	apiServer.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "config.openshift.io",
		Version: "v1",
		Kind:    "APIServer",
	})
	if err := bootstrapClient.Get(context.Background(), client.ObjectKey{Name: "cluster"}, apiServer); err != nil {
		if apierrors.IsNotFound(err) || meta.IsNoMatchError(err) {
			setupLog.Info("TLS profile not available, using hardened defaults (non-OpenShift cluster)")
			tlsOpts = append(tlsOpts, func(c *tls.Config) {
				c.MinVersion = tls.VersionTLS12
				c.CipherSuites = intermediateCiphers
				c.NextProtos = []string{"h2", "http/1.1"}
			})
		} else {
			setupLog.Error(err, "Failed to read APIServer TLS profile, operator cannot start without TLS policy")
			os.Exit(1)
		}
	} else {
		minVersion, ciphers := parseTLSProfile(apiServer)
		if ciphers != nil && len(ciphers) == 0 {
			setupLog.Error(nil, "Custom TLS profile specified ciphers but none are supported by Go, "+
				"refusing to start with unrestricted ciphers")
			os.Exit(1)
		}
		setupLog.Info("Applying cluster TLS profile", "minVersion", minVersion, "ciphers", len(ciphers))
		tlsOpts = append(tlsOpts, func(c *tls.Config) {
			c.MinVersion = minVersion
			if len(ciphers) > 0 {
				c.CipherSuites = ciphers
			}
			c.NextProtos = []string{"h2", "http/1.1"}
		})
	}
	return tlsOpts
}

var tlsVersionMap = map[string]uint16{
	"VersionTLS12": tls.VersionTLS12,
	"VersionTLS13": tls.VersionTLS13,
}

var openSSLToGoCipher = map[string]uint16{
	"ECDHE-ECDSA-AES128-GCM-SHA256": tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
	"ECDHE-RSA-AES128-GCM-SHA256":   tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
	"ECDHE-ECDSA-AES256-GCM-SHA384": tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
	"ECDHE-RSA-AES256-GCM-SHA384":   tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
	"ECDHE-ECDSA-CHACHA20-POLY1305": tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
	"ECDHE-RSA-CHACHA20-POLY1305":   tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
	"ECDHE-ECDSA-AES128-SHA256":     tls.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,
	"ECDHE-RSA-AES128-SHA256":       tls.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256,
	"AES128-GCM-SHA256":             tls.TLS_RSA_WITH_AES_128_GCM_SHA256,
	"AES256-GCM-SHA384":             tls.TLS_RSA_WITH_AES_256_GCM_SHA384,
	"AES128-SHA256":                 tls.TLS_RSA_WITH_AES_128_CBC_SHA256,
}

var intermediateMinVersion uint16 = tls.VersionTLS12
var intermediateCiphers = []uint16{
	tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
	tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
	tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
	tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
	tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
	tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
}

func parseTLSProfile(apiServer *unstructured.Unstructured) (uint16, []uint16) {
	profile, found, err := unstructured.NestedMap(apiServer.Object, "spec", "tlsSecurityProfile")
	if err != nil {
		setupLog.Error(err, "Failed to read tlsSecurityProfile from APIServer, using Intermediate defaults")
		return intermediateMinVersion, intermediateCiphers
	}
	if !found || profile == nil {
		return intermediateMinVersion, intermediateCiphers
	}

	profileType, _ := profile["type"].(string)
	switch profileType {
	case "Intermediate", "":
		return intermediateMinVersion, intermediateCiphers
	case "Custom":
		custom, _, err := unstructured.NestedMap(profile, "custom")
		if err != nil {
			setupLog.Error(err, "Failed to read custom TLS profile, using Intermediate defaults")
			return intermediateMinVersion, intermediateCiphers
		}
		if custom == nil {
			setupLog.Info("Custom TLS profile type set but no custom block provided, using Intermediate defaults")
			return intermediateMinVersion, intermediateCiphers
		}
		minVer, _ := custom["minTLSVersion"].(string)
		minVersion := tlsVersionMap[minVer]
		if minVersion == 0 {
			minVersion = tls.VersionTLS12
		}
		cipherNames, _, err := unstructured.NestedStringSlice(custom, "ciphers")
		if err != nil {
			setupLog.Error(err, "Failed to read ciphers from custom TLS profile, proceeding without cipher restrictions")
		}
		ciphers := make([]uint16, 0, len(cipherNames))
		for _, name := range cipherNames {
			if id, ok := openSSLToGoCipher[name]; ok {
				ciphers = append(ciphers, id)
			} else {
				setupLog.Info("Cipher from TLS profile not supported by Go, skipping", "cipher", name)
			}
		}
		return minVersion, ciphers
	case "Modern":
		return tls.VersionTLS13, nil
	case "Old":
		return tls.VersionTLS12, nil
	default:
		setupLog.Info("Unrecognized TLS profile type, using Intermediate defaults", "profileType", profileType)
		return intermediateMinVersion, intermediateCiphers
	}
}

func main() {
	var metricsAddr string
	var enableLeaderElection bool
	var probeAddr string
	var configMap string
	var enabledServices controllers.EnabledServices
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "The address and port the metric endpoint binds to.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "The address the probe endpoint binds to.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false,
		"Enable leader election for controller manager. "+
			"Enabling this will ensure there is only one active controller manager.")
	flag.Var(&enabledServices, "enable-services", "Specify a list of services to enable and use ',' as the separator")
	flag.StringVar(&configMap, "configmap", constants.ConfigMap, "The configmap that stores settings for the operator")
	opts := zap.Options{
		Development: true,
	}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	if enabledServices.Empty() {
		setupLog.Error(fmt.Errorf("no service is specified"), "please specify at least one service")
		os.Exit(1)
	}

	cfg := ctrl.GetConfigOrDie()
	tlsOpts := fetchTLSOpts(cfg)

	mgrOpts := ctrl.Options{
		Scheme:                 scheme,
		Metrics:                server.Options{BindAddress: metricsAddr, TLSOpts: tlsOpts},
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "b7e9931f.trustyai.opendatahub.io",
		// Disable caching for high-volume core resources to prevent OOM from
		// cluster-wide informer cache flooding. When the cached client encounters
		// a Get/List for these types, it will bypass the cache and read directly
		// from the API server (~50ms vs ~1ms, acceptable for infrequent reads).
		// This prevents r.Client.Get() from silently creating a cluster-wide
		// informer that caches ALL objects of the type across ALL namespaces.
		Client: client.Options{
			Cache: &client.CacheOptions{
				DisableFor: []client.Object{
					&corev1.ConfigMap{},
					&corev1.Secret{},
					&corev1.Pod{},
					&corev1.Service{},
				},
			},
		},
		WebhookServer: ctrlwebhook.NewServer(ctrlwebhook.Options{
			Port:    9443,
			TLSOpts: tlsOpts,
		}),
		// LeaderElectionReleaseOnCancel: true,
	}

	if slices.Contains(enabledServices, serviceEvalHub) {
		mgrOpts.WebhookServer = ctrlwebhook.NewServer(ctrlwebhook.Options{
			Port: 9443,
		})
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), mgrOpts)
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if slices.Contains(enabledServices, serviceEvalHub) {
		if err := ctrl.NewWebhookManagedBy(mgr).For(&evalhubv1.EvalHub{}).Complete(); err != nil {
			setupLog.Error(err, "unable to create EvalHub conversion webhook")
			os.Exit(1)
		}
	}

	recorder := mgr.GetEventRecorderFor("trustyai-service-operator")

	ns, err := utils.GetNamespace()
	if err != nil {
		setupLog.Error(err, "unable to operator's namespace")
	}

	if err = controllers.SetupControllers(enabledServices, mgr, ns, configMap, recorder); err != nil {
		setupLog.Error(err, "unable to initialize controller(s)")
		os.Exit(1)
	}
	//+kubebuilder:scaffold:builder

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}

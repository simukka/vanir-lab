// Command eviction-notice runs the notice controller (see internal/notice).
package main

import (
	"flag"
	"os"
	"time"

	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	kueue "sigs.k8s.io/kueue/apis/kueue/v1beta2"

	"github.com/simukka/vanir-lab/modules/07-controller/internal/notice"
)

func main() {
	var metricsAddr, probeAddr string
	var poll time.Duration
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "plain-HTTP metrics (lab only)")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "health probes")
	flag.DurationVar(&poll, "poll-interval", 2*time.Second, "re-check interval for terminating victims")
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	setupLog := ctrl.Log.WithName("setup")

	scheme := runtime.NewScheme()
	must(clientgoscheme.AddToScheme(scheme))
	must(kueue.AddToScheme(scheme))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: probeAddr,
	})
	if err != nil {
		setupLog.Error(err, "creating manager")
		os.Exit(1)
	}

	r := &notice.Reconciler{
		Client:       mgr.GetClient(),
		Recorder:     mgr.GetEventRecorder("eviction-notice"),
		Metrics:      notice.NewMetrics(metrics.Registry),
		Now:          time.Now,
		PollInterval: poll,
	}
	if err := r.SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "setting up controller")
		os.Exit(1)
	}
	must(mgr.AddHealthzCheck("healthz", healthz.Ping))
	must(mgr.AddReadyzCheck("readyz", healthz.Ping))

	setupLog.Info("starting manager")
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "running manager")
		os.Exit(1)
	}
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

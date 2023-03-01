package main

import (
	"context"
	"embed"
	"os"

	restclient "k8s.io/client-go/rest"

	"k8s.io/klog/v2"

	"open-cluster-management.io/addon-framework/pkg/addonmanager"
	"open-cluster-management.io/olm-addon/pkg/hub"
)

//go:embed manifests
var FS embed.FS

func main() {
	kubeconfig, err := restclient.InClusterConfig()
	if err != nil {
		klog.ErrorS(err, "Unable to get in cluster kubeconfig")
		os.Exit(1)
	}
	addonMgr, err := addonmanager.New(kubeconfig)
	if err != nil {
		klog.ErrorS(err, "unable to setup addon manager")
		os.Exit(1)
	}
	agent, err := hub.NewAgent(kubeconfig, FS)
	if err != nil {
		klog.ErrorS(err, "unable to build addon agent")
		os.Exit(1)
	}
	err = addonMgr.AddAgent(agent)
	if err != nil {
		klog.ErrorS(err, "unable to add addon agent to manager")
		os.Exit(1)
	}
	ctx := context.Background()
	klog.Info("starting olm-addon")
	go addonMgr.Start(ctx)
	<-ctx.Done()
}

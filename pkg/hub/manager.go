package hub

import (
	"embed"
	"fmt"
	"os"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"

	restclient "k8s.io/client-go/rest"

	"k8s.io/klog/v2"

	"open-cluster-management.io/addon-framework/pkg/addonfactory"
	agentfw "open-cluster-management.io/addon-framework/pkg/agent"
	addonapiv1alpha1 "open-cluster-management.io/api/addon/v1alpha1"
	addonv1alpha1client "open-cluster-management.io/api/client/addon/clientset/versioned"
	clusterv1 "open-cluster-management.io/api/cluster/v1"
)

const (
	// Label on ManagedCluster - if this label is set to value "true" on a ManagedCluster resource on the hub then
	// the addon controller will automatically create a ManagedClusterAddOn for the managed cluster and thus
	// trigger the deployment of OLM on that managed cluster
	ManagedClusterInstallLabel      = "addons.open-cluster-management.io/non-openshift"
	ManagedClusterInstallLabelValue = "true"
	addonName                       = "olm-addon"
	templatePath                    = "manifests"
)

func NewAgent(kubeconfig *restclient.Config, fs embed.FS) (agentfw.AgentAddon, error) {
	addonClient, err := addonv1alpha1client.NewForConfig(kubeconfig)
	if err != nil {
		klog.ErrorS(err, "unable to setup addon client")
		os.Exit(1)
	}
	return addonfactory.NewAgentAddonFactory(addonName, fs, templatePath).
		WithConfigGVRs(
			schema.GroupVersionResource{Group: "addon.open-cluster-management.io", Version: "v1alpha1", Resource: "addondeploymentconfigs"},
		).
		WithGetValuesFuncs(
			getValuesFromManager,
			addonfactory.GetValuesFromAddonAnnotation,
			addonfactory.GetAddOnDeloymentConfigValues(
				addonfactory.NewAddOnDeloymentConfigGetter(addonClient),
				addonfactory.ToAddOnDeloymentConfigValues,
			)).
		WithInstallStrategy(agentfw.InstallByLabelStrategy(
			"", /* this controller will ignore the ns in the spec so set to empty */
			metav1.LabelSelector{
				MatchLabels: map[string]string{
					ManagedClusterInstallLabel: ManagedClusterInstallLabelValue,
				},
			})).
		BuildTemplateAgentAddon()
}

func getValuesFromManager(_ *clusterv1.ManagedCluster,
	addon *addonapiv1alpha1.ManagedClusterAddOn) (addonfactory.Values, error) {
	return addonfactory.Values{"AddonName": fmt.Sprintf("%s-agent", addonName)}, nil
}
